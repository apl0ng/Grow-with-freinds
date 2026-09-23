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
	_tag_label.text = "SEED PACKET"
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
func refresh(money: int, hands_full: bool) -> void:
	if kind == KIND_SEED and seed_def != null:
		_refresh_seed(money, hands_full)
	elif kind == KIND_UPGRADE and upgrade_def != null:
		_refresh_upgrade(money)


func get_buy_button() -> Button:
	return _buy


func is_buy_enabled() -> bool:
	return not _buy.disabled


func get_stats_text() -> String:
	var parts := PackedStringArray([_stat1.text, _stat2.text])
	if _stat3.visible:
		parts.append(_stat3.text)
	return "\n".join(parts)


func _refresh_seed(money: int, hands_full: bool) -> void:
	var grow_mult := maxf(GameState.get_growth_speed_multiplier(), 0.01)
	var grow_sec := Config.balance.total_grow_time(seed_def) / grow_mult
	_stat1.text = "Grows in ~%d s" % roundi(grow_sec)
	var sale_mult := GameState.get_sale_multiplier()
	var total := int(round(seed_def.yield_amount * seed_def.sale_value_per_unit * sale_mult))
	if seed_def.yield_amount > 1:
		var per_unit := int(round(seed_def.sale_value_per_unit * sale_mult))
		_stat2.text = "Deposits for $%d  (%d × $%d)" % [total, seed_def.yield_amount, per_unit]
	else:
		_stat2.text = "Deposits for $%d" % total
	var profit := total - seed_def.cost
	_stat3.text = "Margin %s$%d" % ["+" if profit >= 0 else "-", absi(profit)]
	_stat3.theme_type_variation = &"SuccessLabel" if profit >= 0 else &"ErrorLabel"
	var affordable := money >= seed_def.cost
	if hands_full:
		_buy.text = "HANDS FULL"
		_buy.tooltip_text = "Put down what you're carrying first."
	else:
		_buy.text = "BUY  $%d" % seed_def.cost
		_buy.tooltip_text = "" if affordable else "Not enough cash."
	_buy.disabled = hands_full or not affordable


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
			return "+%d%% sale value" % roundi(total * 100.0)
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

