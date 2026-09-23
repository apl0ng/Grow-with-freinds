class_name WateringCan
extends Item
## Watering can: `charges` (synced) are spent on plots and refilled at the well (both server side).
## Visuals: water gauge on the back (faces the player when held), water surface on top while not empty,
## floating "3/4" label while lying on the floor.

## Height of the gauge fill mesh at 100% (matches the Fill BoxMesh size.y in watering_can.tscn).
const GAUGE_HEIGHT: float = 0.16
## Label tint when the can is empty (palette "tomato", see scripts/art/toon.gd).
const EMPTY_COLOR := Color("ff5a5f")

## Charges left (synced, server authority). Capacity comes from GameState (upgrades add charges).
var charges: int = 0:
	set = _set_charges

@onready var _gauge_fill: MeshInstance3D = $Visual/Gauge/Fill
@onready var _water_top: MeshInstance3D = $Visual/WaterTop
@onready var _label: Label3D = $ChargeLabel

func _ready() -> void:
	super()
	if not GameState.upgrade_level_changed.is_connected(_on_upgrade_level_changed):
		GameState.upgrade_level_changed.connect(_on_upgrade_level_changed)

func get_capacity() -> int:
	return maxi(1, GameState.get_can_capacity())

func is_empty() -> bool:
	return charges <= 0

func is_full() -> bool:
	return charges >= get_capacity()

func get_display_name() -> String:
	return "Watering Can"

func get_status_text() -> String:
	return "%d/%d" % [charges, get_capacity()]

## props: {"charges": int}; a missing value means a full can.
func apply_props(props: Dictionary) -> void:
	charges = int(props.get("charges", get_capacity()))

func get_props() -> Dictionary:
	return {"charges": charges}

func _set_charges(value: int) -> void:
	value = maxi(value, 0)
	if value == charges:
		return
	charges = value
	_notify_props_changed()

func _refresh_visuals() -> void:
	var capacity := get_capacity()
	var fill := clampf(float(charges) / float(capacity), 0.0, 1.0)
	_gauge_fill.visible = fill > 0.0
	if fill > 0.0:
		# The fill mesh is centred on its node: scale from the bottom of the gauge.
		_gauge_fill.scale = Vector3(1.0, fill, 1.0)
		_gauge_fill.position.y = GAUGE_HEIGHT * fill * 0.5
	_water_top.visible = charges > 0
	_label.text = get_status_text()
	_label.modulate = EMPTY_COLOR if charges <= 0 else Color.WHITE
	_label.visible = not is_held()

func _on_upgrade_level_changed(_upgrade_id: StringName, _level: int) -> void:
	if is_node_ready():
		_refresh_visuals()
