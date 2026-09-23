class_name Product
extends Item
## Harvested product: a puffy bud cluster tinted with the strain color, bigger for larger amounts.
## Created by harvesting a READY GrowPlot, destroyed when sold at the TurnInStation.

## Tint used when the strain id is unknown.
const UNKNOWN_COLOR := Color(0.7, 0.7, 0.7)
## Visual scale per extra unit of product (amount 1 = 1.0), capped at MAX_VISUAL_SCALE.
const SCALE_PER_UNIT: float = 0.15
const MAX_VISUAL_SCALE: float = 1.6

## Strain id (SeedDef.id), synced (server authority).
var strain_id: StringName = &"":
	set = _set_strain_id
## Units of product, synced (server authority).
var amount: int = 1:
	set = _set_amount

var _tint: StandardMaterial3D = null

@onready var _cluster: Node3D = $Visual/Cluster
@onready var _buds: Node3D = $Visual/Cluster/Buds
@onready var _label: Label3D = $AmountLabel

func get_seed() -> SeedDef:
	return Config.balance.get_seed(strain_id)

func get_strain_name() -> String:
	var def := get_seed()
	return def.display_name if def != null else "Mystery Bud"

## "<Strain> x<amount>", e.g. "Purple Haze x2".
func get_display_name() -> String:
	return "%s x%d" % [get_strain_name(), amount]

## props: {"strain_id": StringName, "amount": int}. Other keys (e.g. a precomputed "value") are ignored.
func apply_props(props: Dictionary) -> void:
	strain_id = StringName(str(props.get("strain_id", strain_id)))
	amount = int(props.get("amount", amount))

func get_props() -> Dictionary:
	return {"strain_id": String(strain_id), "amount": amount}

func _set_strain_id(value: StringName) -> void:
	if value == strain_id:
		return
	strain_id = value
	_notify_props_changed()

func _set_amount(value: int) -> void:
	value = maxi(value, 1)
	if value == amount:
		return
	amount = value
	_notify_props_changed()

func _refresh_visuals() -> void:
	var def := get_seed()
	var color := def.color if def != null else UNKNOWN_COLOR
	if _tint == null:
		var first := _buds.get_child(0) as MeshInstance3D
		var base := first.material_override as StandardMaterial3D if first != null else null
		_tint = base.duplicate() as StandardMaterial3D if base != null else StandardMaterial3D.new()
		for child in _buds.get_children():
			var mesh := child as MeshInstance3D
			if mesh != null:
				mesh.material_override = _tint
	_tint.albedo_color = color
	if _tint.emission_enabled:
		_tint.emission = color
	_cluster.scale = Vector3.ONE * minf(1.0 + SCALE_PER_UNIT * float(amount - 1), MAX_VISUAL_SCALE)
	_label.text = "x%d" % amount
	_label.visible = not is_held()
