class_name Product
extends Item
## Harvested product: a taped bag of product (art/models/product_bundle.glb instanced as Visual/Cluster) whose
## buds (Cluster/Buds/Bud0) take the graded strain colour; the whole Cluster grows with the amount.
## Created by harvesting a READY GrowPlot, destroyed when sold at the TurnInStation.
##
## M14 loop (drying, see DryingRack): three more synced props. `rack` is true while the bundle hangs on a rack hook,
## `dry_left` is the hanging time it still needs (0 = never hung, or done) and `cured` marks a bundle that hung for
## the whole Config.balance.cure_sec: it is tinted darker, its label reads "Cured" and the chute pays 1 + cure_bonus
## for it. Only the host's DryingRack writes them. In the replication config `rack` comes BEFORE `holder_id`: the
## release that puts a bundle on a hook then already knows it is a hang (the `rack_hang` sound instead of the floor
## thud), on the host and on every client alike.

## Tint used when the strain id is unknown.
const UNKNOWN_COLOR := Color(0.7, 0.7, 0.7)
## Visual scale per extra unit of product (amount 1 = 1.0), capped at MAX_VISUAL_SCALE.
const SCALE_PER_UNIT: float = 0.15
const MAX_VISUAL_SCALE: float = 1.6
## M14 loop: how much darker a cured bundle's strain colour is.
const CURED_DARKEN: float = 0.4

## Strain id (SeedDef.id), synced (server authority).
var strain_id: StringName = &"":
	set = _set_strain_id
## Units of product, synced (server authority).
var amount: int = 1:
	set = _set_amount
## M14 loop, synced (server authority): true while the bundle hangs on a DryingRack hook.
var rack: bool = false:
	set = _set_rack
## M14 loop, synced (server authority): seconds of hanging the bundle still needs (0 = never hung, or cured). The
## rack writes it in DryingRack.SYNC_STEP steps while the bundle hangs and exactly when it is taken off.
var dry_left: float = 0.0:
	set = _set_dry_left
## M14 loop, synced (server authority): the bundle hung for the whole cure time.
var cured: bool = false:
	set = _set_cured

var _tint: StandardMaterial3D = null
var _label_rest_y: float = -1.0

@onready var _cluster: Node3D = $Visual/Cluster
@onready var _buds: Node3D = $Visual/Cluster/Buds
@onready var _label: Label3D = $AmountLabel

func get_seed() -> SeedDef:
	return Config.balance.get_seed(strain_id)

func get_strain_name() -> String:
	var def := get_seed()
	return def.display_name if def != null else "Unmarked product"

## "<Strain> x<amount>", e.g. "Purple Haze x2".
func get_display_name() -> String:
	return "%s x%d" % [get_strain_name(), amount]

## M14 loop: what the worker needs to know about the bundle in hand or under the crosshair: "Heavy", "Cured",
## "Drying 14 s" (on a hook), "6 s to dry" (taken off early). "" for a plain fresh bundle.
func get_status_text() -> String:
	var parts := PackedStringArray()
	if is_heavy():
		parts.append("Heavy")
	if cured:
		parts.append("Cured")
	elif rack:
		parts.append("Drying %d s" % ceili(dry_left))
	elif dry_left > 0.0:
		parts.append("%d s to dry" % ceili(dry_left))
	return ", ".join(parts)

## M14 loop: the strain's bundle is heavy (SeedDef.heavy): its carrier walks slower and cannot sprint (Player).
func is_heavy() -> bool:
	var def := get_seed()
	return def != null and def.heavy

## M14 loop: true while the bundle hangs on a rack hook and is not cured yet.
func is_drying() -> bool:
	return rack and not cured

## M14 loop: the floating label over a bundle that lies or hangs somewhere: "x2", "x2 · 14 s" on a hook, "Cured x2".
func get_tag_text() -> String:
	if cured:
		return "Cured x%d" % amount
	if rack:
		return "x%d · %d s" % [amount, ceili(dry_left)]
	return "x%d" % amount

## props: {"strain_id": StringName, "amount": int} plus, optionally, the M14 drying state {"rack": bool,
## "dry_left": float, "cured": bool}. Other keys (e.g. a precomputed "value") are ignored.
func apply_props(props: Dictionary) -> void:
	strain_id = StringName(str(props.get("strain_id", strain_id)))
	amount = int(props.get("amount", amount))
	rack = bool(props.get("rack", rack))
	dry_left = float(props.get("dry_left", dry_left))
	cured = bool(props.get("cured", cured))

## The drying keys only appear once they differ from a fresh bundle's, so a plain bundle's props stay the two it
## always had.
func get_props() -> Dictionary:
	var props := {"strain_id": String(strain_id), "amount": amount}
	if rack:
		props["rack"] = true
	if dry_left > 0.0:
		props["dry_left"] = dry_left
	if cured:
		props["cured"] = true
	return props

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

func _set_rack(value: bool) -> void:
	if value == rack:
		return
	rack = value
	_notify_props_changed()

func _set_dry_left(value: float) -> void:
	value = maxf(value, 0.0) if is_finite(value) else 0.0
	if value == dry_left:
		return
	dry_left = value
	_notify_props_changed()

func _set_cured(value: bool) -> void:
	if value == cured:
		return
	cured = value
	if value and is_node_ready() and is_inside_tree():
		# Every peer (the setter runs from the sync too): a dry rustle, a little dust, no celebration.
		Sfx.play(&"cured", global_position)
		Juice.puff(global_position + Vector3.UP * 0.2, Juice.GLOOM, 4)
		Juice.bounce(get_visual(), 0.2)
	_notify_props_changed()

## M14 loop: a release that leaves the bundle on a rack hook is a hang (`rack` is set before the holder is cleared, on
## every peer): the hook takes the weight instead of the floor thud.
func _play_holder_effects(old_holder: int, new_holder: int) -> void:
	if new_holder == 0 and old_holder != 0 and rack and not is_flying() and is_inside_tree():
		Sfx.play(&"rack_hang", global_position)
		Juice.bounce(get_visual())
		return
	super(old_holder, new_holder)

func _refresh_visuals() -> void:
	var def := get_seed()
	# Data colours are mood-graded (STYLE.md): the same colour the plant's buds and the seed packet use.
	var color := Toon.grade(def.color if def != null else UNKNOWN_COLOR)
	if cured:
		color = color.darkened(CURED_DARKEN) # M14 loop: dried buds are darker
	var model := _cluster as Toonify
	if model != null and model.tint != color: # (the drying countdown refreshes the label twice a second: no re-toonify)
		model.tint = color # any other TINT part of the bundle model
	if _tint == null:
		# Per-instance copy of the buds' Toonify material, re-tinted in place (never the shared cache).
		var first := _buds.get_child(0) as MeshInstance3D
		var src := first.mesh.surface_get_material(0) if first != null and first.mesh != null else null
		var base := Toonify.toon_material(src, -1.0, color) as StandardMaterial3D
		_tint = base.duplicate() as StandardMaterial3D if base != null else Toon.make(color)
		for child in _buds.get_children():
			var mesh := child as MeshInstance3D
			if mesh != null:
				mesh.material_override = _tint
	_tint.albedo_color = color
	if _tint.emission_enabled:
		_tint.emission = color
	var s := minf(1.0 + SCALE_PER_UNIT * float(amount - 1), MAX_VISUAL_SCALE)
	_cluster.scale = Vector3.ONE * s
	# The floating label rides above the (scaled) bundle: its scene height is the amount-1 height.
	if _label_rest_y < 0.0:
		_label_rest_y = _label.position.y
	_label.position.y = _label_rest_y * s
	_label.text = get_tag_text()
	_label.visible = not is_held()
